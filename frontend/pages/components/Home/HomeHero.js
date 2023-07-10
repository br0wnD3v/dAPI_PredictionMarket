import {
  Box,
  Flex,
  Heading,
  Text,
  CircularProgress,
  Link,
} from "@chakra-ui/react";

import Create from "./Hero/Create";
import Buy from "./Hero/Buy";

import "@fontsource/barlow/800.css";
import { useAccount } from "wagmi";
import { FadeInWhenVisible } from "../TransitionBoxes";

export default function HomeHero({ page }) {
  const { isConnected } = useAccount();

  return (
    <>
      <Box align="center">
        {!isConnected ? (
          <>
            <CircularProgress
              mt={200}
              isIndeterminate
              color="blue.700"
              thickness="5px"
              size="100px"
            />
          </>
        ) : (
          <>
            {page == "Home" ? (
              <>
                <FadeInWhenVisible>
                  <Flex
                    as="motion.div"
                    direction="column"
                    margin={20}
                    align="center"
                    justify="center"
                    h="500px"
                  >
                    <Heading fontFamily="Barlow" fontSize="90px">
                      Prediction Markets Powered By{" "}
                      <Link
                        href="https://market.api3.org/dapis"
                        target="_blank"
                      >
                        API3's dAPIs
                      </Link>
                    </Heading>
                    <Text fontSize="30px" w="80%" mt={10}>
                      Get started by clicking on the `Buy` tab if you are
                      looking to bet on some predictions or click on the
                      `Create` tab if you looking to create your very own
                      Prediction Market.
                    </Text>
                  </Flex>
                </FadeInWhenVisible>
              </>
            ) : page == "Create" ? (
              <>
                <Create />
              </>
            ) : (
              <>
                <Buy />
              </>
            )}
          </>
        )}
      </Box>
    </>
  );
}
